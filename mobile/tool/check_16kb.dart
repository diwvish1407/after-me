// The 16 KB memory page size check (PLAY_STORE §3; Play requires it for apps targeting
// Android 15+, and AfterMe targets 36): every native library a 64-bit phone loads must
// have its ELF LOAD segments aligned to at least 16 KB, or the app does not start on a
// device with 16 KB pages.
//
//   dart run tool/check_16kb.dart [path/to/app.aab|app.apk]
//
// From mobile/. Without a path it checks the prod release bundle
// (build/app/outputs/bundle/prodRelease/app-prod-release.aab), or the prod release APK
// when there is no bundle. tool/build_release.sh runs it on what it just built, after the
// manifest check.
//
// What it does:
//   1. lists every `.so` in the archive (`unzip`, present on macOS and Linux) and reads
//      its ELF program headers: every PT_LOAD segment of a 64-bit library (arm64-v8a,
//      x86_64) must have p_align >= 16384. A 32-bit library (armeabi-v7a, x86) is only
//      reported: 16 KB pages exist on 64-bit devices only;
//   2. for an APK, the zip alignment of the uncompressed libraries: `zipalign -c -P 16 -v 4`
//      from the newest Android build-tools ($ANDROID_HOME, $ANDROID_SDK_ROOT or
//      ~/Library/Android/sdk). For a bundle, Play (bundletool) aligns the APKs it
//      generates; the ELF check is the part that the bundle decides.
//
// Exit 0 when aligned; 1 with every misaligned library named (loudly); 2 when the
// archive cannot be read or holds no native library at all (a Flutter app always has
// libflutter.so and libapp.so, so that is a broken build, not a pass).
import 'dart:io';
import 'dart:typed_data';

/// The alignment a LOAD segment needs: 16 KB.
const int pageSize16k = 16384;

const _pLoad = 1;

/// The ABIs whose devices can have 16 KB pages.
const abis64 = {'arm64-v8a', 'x86_64'};

/// One LOAD segment's alignment.
typedef LoadSegment = ({int index, int align});

/// What the ELF header and program headers of a library say.
class ElfReport {
  ElfReport({required this.is64, required this.loadSegments});

  final bool is64;
  final List<LoadSegment> loadSegments;

  /// LOAD segments aligned below 16 KB (or not a power of two).
  List<LoadSegment> get misaligned => [
    for (final s in loadSegments)
      if (s.align < pageSize16k || (s.align & (s.align - 1)) != 0) s,
  ];

  /// The smallest LOAD alignment (0 when there is no LOAD segment).
  int get minAlign => loadSegments.isEmpty
      ? 0
      : loadSegments.map((s) => s.align).reduce((a, b) => a < b ? a : b);
}

/// Reads the program headers of the ELF file in [bytes]. Throws [FormatException] for
/// anything that is not a little-endian ELF32/ELF64 file (Android's libraries all are).
ElfReport readElf(Uint8List bytes) {
  if (bytes.length < 52 ||
      bytes[0] != 0x7F ||
      bytes[1] != 0x45 ||
      bytes[2] != 0x4C ||
      bytes[3] != 0x46) {
    throw const FormatException('not an ELF file');
  }
  final elfClass = bytes[4]; // 1: 32-bit, 2: 64-bit
  if (elfClass != 1 && elfClass != 2) {
    throw FormatException('unknown ELF class $elfClass');
  }
  if (bytes[5] != 1) {
    throw const FormatException('not a little-endian ELF file');
  }
  final is64 = elfClass == 2;
  final view = ByteData.sublistView(bytes);
  const le = Endian.little;
  final int phoff;
  final int phentsize;
  final int phnum;
  if (is64) {
    if (bytes.length < 64) {
      throw const FormatException('truncated ELF64 header');
    }
    phoff = view.getUint64(32, le);
    phentsize = view.getUint16(54, le);
    phnum = view.getUint16(56, le);
  } else {
    phoff = view.getUint32(28, le);
    phentsize = view.getUint16(42, le);
    phnum = view.getUint16(44, le);
  }
  if (phoff + phnum * phentsize > bytes.length) {
    throw const FormatException('the program headers run past the file');
  }
  final segments = <LoadSegment>[];
  for (var i = 0; i < phnum; i++) {
    final base = phoff + i * phentsize;
    final type = view.getUint32(base, le);
    if (type != _pLoad) {
      continue;
    }
    final align = is64
        ? view.getUint64(base + 48, le)
        : view.getUint32(base + 28, le);
    segments.add((index: i, align: align));
  }
  return ElfReport(is64: is64, loadSegments: segments);
}

/// The ABI directory a library sits in (`lib/<abi>/x.so` in an APK,
/// `base/lib/<abi>/x.so` in a bundle), or null.
String? abiOf(String entry) {
  final parts = entry.split('/');
  final lib = parts.indexOf('lib');
  return lib >= 0 && lib + 2 < parts.length ? parts[lib + 1] : null;
}

/// One library's verdict.
class LibraryVerdict {
  LibraryVerdict(this.entry, this.abi, this.report);

  final String entry;
  final String? abi;
  final ElfReport report;

  /// Whether this library matters for 16 KB pages (a 64-bit library, or one in a 64-bit
  /// ABI directory).
  bool get enforced => report.is64 || abis64.contains(abi);

  bool get ok => !enforced || report.misaligned.isEmpty;

  String describe() {
    final align = report.minAlign;
    final state = !enforced
        ? 'not checked (32-bit: no 16 KB pages)'
        : ok
        ? 'OK'
        : 'MISALIGNED';
    return '$entry: LOAD p_align min $align (0x${align.toRadixString(16)}) $state';
  }
}

/// Checks every library in [libraries] (archive entry name -> ELF bytes).
List<LibraryVerdict> checkLibraries(Map<String, Uint8List> libraries) => [
  for (final MapEntry(key: entry, value: bytes) in libraries.entries)
    LibraryVerdict(entry, abiOf(entry), readElf(bytes)),
];

/// `zipalign` of the newest build-tools, or null.
String? findZipalign() {
  final env = Platform.environment;
  final roots = [
    env['ANDROID_HOME'],
    env['ANDROID_SDK_ROOT'],
    if (env['HOME'] != null) '${env['HOME']}/Library/Android/sdk',
    if (env['HOME'] != null) '${env['HOME']}/Android/Sdk',
  ].whereType<String>();
  for (final root in roots) {
    final dir = Directory('$root/build-tools');
    if (!dir.existsSync()) {
      continue;
    }
    final versions =
        dir.listSync().whereType<Directory>().map((d) => d.path).toList()
          ..sort(_compareVersionPaths);
    for (final version in versions.reversed) {
      final tool = File('$version/zipalign');
      if (tool.existsSync()) {
        return tool.path;
      }
    }
  }
  return null;
}

int _compareVersionPaths(String a, String b) {
  List<int> parts(String path) => [
    for (final p in path.split('/').last.split(RegExp(r'[.-]')))
      int.tryParse(p) ?? 0,
  ];
  final pa = parts(a);
  final pb = parts(b);
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    if (pa[i] != pb[i]) {
      return pa[i].compareTo(pb[i]);
    }
  }
  return pa.length.compareTo(pb.length);
}

/// Extracts the `.so` entries of the zip archive [archive] (an AAB or APK).
Map<String, Uint8List> extractLibraries(String archive) {
  final temp = Directory.systemTemp.createTempSync('afterme-16kb-');
  try {
    final result = Process.runSync('unzip', [
      '-qq',
      '-o',
      archive,
      '*.so',
      '-d',
      temp.path,
    ]);
    // 11: no entry matched (no native library at all), reported by the caller.
    if (result.exitCode != 0 && result.exitCode != 11) {
      throw ProcessException(
        'unzip',
        [archive],
        '${result.stderr}'.trim(),
        result.exitCode,
      );
    }
    final libraries = <String, Uint8List>{};
    for (final file in temp.listSync(recursive: true).whereType<File>()) {
      if (file.path.endsWith('.so')) {
        final entry = file.path.substring(temp.path.length + 1);
        libraries[entry] = file.readAsBytesSync();
      }
    }
    return Map.fromEntries(
      libraries.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
  } finally {
    temp.deleteSync(recursive: true);
  }
}

String? _defaultArtifact() {
  for (final path in [
    'build/app/outputs/bundle/prodRelease/app-prod-release.aab',
    'build/app/outputs/flutter-apk/app-prod-release.apk',
  ]) {
    if (File(path).existsSync()) {
      return path;
    }
  }
  return null;
}

void _banner(String message) {
  stderr
    ..writeln('#' * 72)
    ..writeln('# 16 KB PAGE-SIZE CHECK FAILED')
    ..writeln('# $message')
    ..writeln('#' * 72);
}

void main(List<String> args) {
  final archive = args.isNotEmpty ? args.first : _defaultArtifact();
  if (archive == null || !File(archive).existsSync()) {
    stderr.writeln(
      'check_16kb: no artifact to check (${archive ?? 'no prod release bundle or APK '
              'under build/app/outputs'}). Build it with tool/build_release.sh first.',
    );
    exit(2);
  }

  final Map<String, Uint8List> libraries;
  final List<LibraryVerdict> verdicts;
  try {
    libraries = extractLibraries(archive);
    verdicts = checkLibraries(libraries);
  } on Object catch (error) {
    stderr.writeln('check_16kb: cannot read $archive: $error');
    exit(2);
  }
  if (libraries.isEmpty) {
    stderr.writeln(
      'check_16kb: $archive holds no native library at all. A Flutter build always '
      'has libflutter.so and libapp.so: this artifact is broken.',
    );
    exit(2);
  }

  stdout.writeln('16 KB page-size check of $archive:');
  for (final verdict in verdicts) {
    stdout.writeln('  ${verdict.describe()}');
  }
  final bad = verdicts.where((v) => !v.ok).toList();
  if (bad.isNotEmpty) {
    _banner(
      '${bad.length} native librar${bad.length == 1 ? 'y is' : 'ies are'} not '
      '16 KB-aligned. Play refuses such an app for Android 15+ targets, and it does not '
      'start on 16 KB-page phones.',
    );
    for (final verdict in bad) {
      stderr.writeln(
        '  ${verdict.entry}: LOAD segments '
        '${verdict.report.misaligned.map((s) => '#${s.index} align ${s.align}').join(', ')}',
      );
    }
    stderr.writeln(
      '  Update the library (or the Flutter/NDK/AGP version that builds it) to a '
      '16 KB-aligned release.',
    );
    exit(1);
  }

  if (archive.endsWith('.apk')) {
    final zipalign = findZipalign();
    if (zipalign == null) {
      stderr.writeln(
        'check_16kb: WARNING: zipalign was not found (Android build-tools); the zip '
        'alignment of the APK was NOT checked, only the ELF segments.',
      );
    } else {
      final result = Process.runSync(zipalign, [
        '-c',
        '-P',
        '16',
        '-v',
        '4',
        archive,
      ]);
      if (result.exitCode != 0) {
        final lines = '${result.stdout}'
            .split('\n')
            .where((l) => l.contains('BAD') || l.contains('.so'))
            .take(20);
        _banner(
          'zipalign -c -P 16 -v 4 refused $archive: the uncompressed native '
          'libraries are not on 16 KB boundaries in the zip.',
        );
        lines.forEach(stderr.writeln);
        stderr.writeln('${result.stderr}'.trim());
        exit(1);
      }
      stdout.writeln('  zip alignment: OK (zipalign -c -P 16 -v 4, $zipalign)');
    }
  } else {
    stdout.writeln(
      '  zip alignment: not applicable to a bundle (Play aligns the APKs it '
      'generates from it).',
    );
  }
  final checked = verdicts.where((v) => v.enforced).length;
  stdout.writeln(
    'OK: $checked 64-bit native librar${checked == 1 ? 'y is' : 'ies are'} '
    '16 KB-aligned (${verdicts.length - checked} 32-bit not applicable).',
  );
}
