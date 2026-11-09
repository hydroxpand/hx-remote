// HX: last-screen previews for peer cards.
// A remote session saves one screenshot a few seconds after its first frame
// (see FFI._hxScheduleThumb), and peer cards show the newest one as their
// background. Files live in <app support dir>/hx_thumbs/<peer id>_<time>.png;
// a new name per capture avoids stale image-cache hits, older files are deleted.
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class HxThumbs {
  static String? _dir;
  static Future<String>? _init;

  static Future<String> dir() {
    if (_dir != null) return Future.value(_dir!);
    return _init ??= () async {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}${Platform.pathSeparator}hx_thumbs');
      if (!d.existsSync()) d.createSync(recursive: true);
      _dir = d.path;
      return d.path;
    }();
  }

  static String _prefix(String peerId) =>
      '${peerId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}_';

  static List<File> _files(String peerId) {
    final d = _dir;
    if (d == null) return [];
    final prefix = _prefix(peerId);
    try {
      return Directory(d)
          .listSync()
          .whereType<File>()
          .where((f) {
            final name = f.uri.pathSegments.last;
            return name.startsWith(prefix) && name.endsWith('.png');
          })
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    } catch (_) {
      return [];
    }
  }

  /// Newest preview for a peer, or null. Synchronous so cards can call it in
  /// build; before the folder is known it starts the lookup and returns null
  /// (the card shows the preview on its next rebuild).
  static File? latest(String peerId) {
    if (_dir == null) {
      dir();
      return null;
    }
    final files = _files(peerId);
    return files.isEmpty ? null : files.last;
  }

  static Future<String> newPath(String peerId) async {
    final d = await dir();
    final ts = DateTime.now().millisecondsSinceEpoch.toString().padLeft(15, '0');
    return '$d${Platform.pathSeparator}${_prefix(peerId)}$ts.png';
  }

  /// Delete every preview of the peer except [keepPath].
  static void prune(String peerId, String keepPath) {
    for (final f in _files(peerId)) {
      if (f.path != keepPath) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    }
  }
}
